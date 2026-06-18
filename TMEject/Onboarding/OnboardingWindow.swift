import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private var closeDelegate: SetupWindowCloseDelegate?

    func show(coordinator: AppCoordinator, onComplete: @escaping () -> Void) {
        guard let screen = NSScreen.main else { return }
        if let win = window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            return
        }

        let width: CGFloat = 420
        let height: CGFloat = 420
        let visible = screen.visibleFrame
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width, height: height
        )

        let view = OnboardingView(coordinator: coordinator, onComplete: { [weak self] in
            self?.dismiss()
            onComplete()
        })

        let win = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .modalPanel
        win.identifier = .tmejectSetupWindow
        let hosting = NSHostingView(rootView: view.frame(width: width))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.autoresizingMask = [.width, .height]
        win.contentView = hosting

        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
        UIActionLogger.windowOpened("Onboarding")

        self.window = win
    }

    private func dismiss() {
        guard let win = window else { return }
        UIActionLogger.windowClosed("Onboarding")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            win.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                win.orderOut(nil)
                self?.window = nil
            }
        })
    }
}
