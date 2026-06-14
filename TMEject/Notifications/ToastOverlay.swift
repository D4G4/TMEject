import AppKit
import SwiftUI

@MainActor
protocol ToastPresenter: AnyObject {
    func present(level: AppCommand.ToastLevel,
                 message: String,
                 subtitle: String?,
                 kind: AppCoordinator.ToastKind,
                 actionLabel: String?)
}

@MainActor
final class ToastOverlay: ToastPresenter {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    static let displayDuration: TimeInterval = 3.0
    static let fadeDuration: TimeInterval = 0.3

    func present(level: AppCommand.ToastLevel,
                 message: String,
                 subtitle: String?,
                 kind: AppCoordinator.ToastKind,
                 actionLabel: String?) {
        dismissTask?.cancel()
        let panel = panel ?? makePanel()
        self.panel = panel

        let view = ToastView(kind: kind, title: message, subtitle: subtitle,
                              actionLabel: actionLabel, onAction: nil)
        let host = NSHostingController(rootView: view)
        panel.contentViewController = host

        let intrinsic = host.view.fittingSize
        if let screen = NSScreen.main {
            let frame = NSRect(
                x: screen.visibleFrame.maxX - intrinsic.width - 14,
                y: screen.visibleFrame.maxY - intrinsic.height - 38,
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

/// Per-design rendering — small 30pt rounded icon chip + title + optional subtitle + optional
/// action. Width 300, matches `surfaces.css::.toast`.
private struct ToastView: View {
    let kind: AppCoordinator.ToastKind
    let title: String
    let subtitle: String?
    let actionLabel: String?
    let onAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            iconChip
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let label = actionLabel {
                Button(label) { onAction?() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var iconChip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(chipBackground)
                .frame(width: 30, height: 30)
            iconBody
                .foregroundStyle(iconColor)
        }
    }

    @ViewBuilder
    private var iconBody: some View {
        switch kind {
        case .ok:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
        case .err:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
        case .busy:
            RingProgress(size: 16, stroke: 2, pct: nil, color: .blue)
        case .neutral:
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 13, weight: .semibold))
        }
    }

    private var chipBackground: Color {
        switch kind {
        case .ok:      return Color.green.opacity(0.16)
        case .err:     return Color.red.opacity(0.16)
        case .busy:    return Color.blue.opacity(0.15)
        case .neutral: return Color.gray.opacity(0.16)
        }
    }

    private var iconColor: Color {
        switch kind {
        case .ok:      return .green
        case .err:     return .red
        case .busy:    return .blue
        case .neutral: return .secondary
        }
    }
}
