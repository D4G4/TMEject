import AppKit
import SwiftUI

@MainActor
protocol ToastPresenter: AnyObject {
    func present(level: AppCommand.ToastLevel, message: String)
}

@MainActor
final class ToastOverlay: ToastPresenter {
    private var panel: NSPanel?
    private var dismissAt: Date?
    private var dismissTask: Task<Void, Never>?

    static let displayDuration: TimeInterval = 3.0
    static let fadeDuration: TimeInterval = 0.3

    func present(level: AppCommand.ToastLevel, message: String) {
        // Replace any in-flight toast — the user wants the latest signal, not a queue.
        dismissTask?.cancel()
        let panel = panel ?? makePanel()
        self.panel = panel

        let view = ToastView(level: level, message: message)
        let host = NSHostingController(rootView: view)
        panel.contentViewController = host

        // Size by content, then top-right of the main screen with a 24pt inset.
        let intrinsic = host.view.fittingSize
        if let screen = NSScreen.main {
            let frame = NSRect(
                x: screen.visibleFrame.maxX - intrinsic.width - 24,
                y: screen.visibleFrame.maxY - intrinsic.height - 24,
                width: intrinsic.width,
                height: intrinsic.height
            )
            panel.setFrame(frame, display: false)
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
        })

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.displayDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func dismiss() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return panel
    }
}

private struct ToastView: View {
    let level: AppCommand.ToastLevel
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.system(size: 16, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(width: 320, alignment: .leading)
    }

    private var iconName: String {
        switch level {
        case .info:    return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    private var iconColor: Color {
        switch level {
        case .info:    return .accentColor
        case .success: return .green
        case .warning: return .yellow
        case .error:   return .red
        }
    }
}
