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

        let width: CGFloat = 640
        let height: CGFloat = 460
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

        let win = NSWindow.makeSetupWindow(contentRect: frame, title: "Welcome to TMEject")
        win.hasShadow = true
        win.contentView = NSHostingView(rootView: view)

        // Closing onboarding without finishing it should not silently put the user in a half-set-up
        // state. We quit — same as Blink's onboarding. The Settings → Advanced → Reset Onboarding
        // button gets the user back here on next launch.
        let close = SetupWindowCloseDelegate { NSApp.terminate(nil) }
        win.delegate = close
        self.closeDelegate = close

        NSApp.setActivationPolicy(.regular)
        win.surfaceAtLaunch()
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
            win.orderOut(nil)
            self?.window = nil
            // Step 11 hands off to the Launch HUD; activation policy stays .regular until
            // the HUD dismisses too.
        })
    }
}
