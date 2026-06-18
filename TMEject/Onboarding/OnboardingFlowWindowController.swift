import AppKit
import SwiftUI

/// Owns the onboarding flow's `NSWindow` and view model lifetimes. Mirrors the pattern
/// `PreferencesWindowController` uses: lift activation policy to `.regular` while the
/// window is open so the user sees a Dock icon + can Cmd-Tab to it, then drop back to
/// `.accessory` on dismissal.
///
/// The HUD is NOT shown while this window is up — `AppDelegate.presentLaunchSurfacesIfNeeded`
/// gates the HUD behind the onboarding window's `onComplete`/`onClose` callbacks.
@MainActor
final class OnboardingFlowWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var model: OnboardingFlowModel?
    /// Held so the close-notification handler can fire it without capturing the @escaping
    /// closure into a Sendable observer block (Swift 6 strict concurrency would reject it).
    private var pendingOnComplete: (() -> Void)?

    func show(coordinator: AppCoordinator,
              fdaProber: FullDiskAccessProbing? = nil,
              notifier: SystemNotifier? = nil,
              onComplete: @escaping () -> Void) {
        if let win = window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            return
        }

        // Live default instances when callers don't override — the coordinator owns its own
        // copies (private), but spinning up additional ones here is cheap: `LiveTMUtilClient`
        // and `LiveSystemNotifier` are stateless apart from a per-instance "hasRequested"
        // flag, and a separate instance is fine for the one-shot ask.
        let prober = fdaProber ?? LiveFullDiskAccessProber(tmutil: LiveTMUtilClient())
        let liveNotifier = notifier ?? LiveSystemNotifier()

        self.pendingOnComplete = onComplete
        let model = OnboardingFlowModel(
            coordinator: coordinator,
            fdaProber: prober,
            notifier: liveNotifier,
            onFinish: { [weak self] in
                guard let self else { return }
                let onComplete = self.pendingOnComplete
                self.pendingOnComplete = nil
                self.dismiss()
                onComplete?()
            }
        )
        self.model = model

        let view = OnboardingFlowView(model: model)

        let width: CGFloat = 480
        let height: CGFloat = 540
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        // Hide the traffic-light buttons — the user advances via the in-window CTAs. The
        // close button stays accessible via Cmd-W (close-observer below treats that the
        // same as "skip from the current step").
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.identifier = .tmejectSetupWindow
        win.title = "Welcome to TMEject"
        win.contentView = NSHostingView(rootView: view)
        win.center()

        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        win.surfaceAtLaunch()
        UIActionLogger.windowOpened("OnboardingFlow")

        if let existing = closeObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleUserClose()
            }
        }

        self.window = win
    }

    /// User-initiated window close (programmatic `orderOut` from `dismiss()` posts a
    /// different notification path and doesn't re-enter here). Treat it as "skip the
    /// rest" so the flow doesn't haunt the user every launch — the spec lets each step
    /// skip to completion, so a window close gets the same treatment.
    private func handleUserClose() {
        guard window != nil else { return }
        UIActionLogger.onboardingStep("user closed window — marking onboarding complete")
        UserDefaults.standard.set(true, forKey: SettingsKey.hasCompletedOnboarding)
        UIActionLogger.windowClosed("OnboardingFlow")
        let onComplete = pendingOnComplete
        pendingOnComplete = nil
        window = nil
        model = nil
        NSApp.setActivationPolicy(.accessory)
        onComplete?()
    }

    private func dismiss() {
        guard let win = window else { return }
        UIActionLogger.windowClosed("OnboardingFlow")
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            win.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                win.orderOut(nil)
                self?.window = nil
                self?.model = nil
                NSApp.setActivationPolicy(.accessory)
            }
        })
    }

    var isShowing: Bool { window != nil }
}
