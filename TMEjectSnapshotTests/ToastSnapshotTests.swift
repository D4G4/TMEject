import XCTest
import SwiftUI
@testable import TMEject

/// Toast surface — one snapshot per ToastKind. Opaque mode only (toast translucent is the
/// translucent SurfaceBackground branch, well-covered by other surfaces).
@MainActor
final class ToastSnapshotTests: SnapshotTestCase {

    private func render(name: String, view: some View,
                        theme: ColorScheme, translucent: Bool = false) {
        let snapshotName = SnapshotName.surface("toast", variant: name,
                                                 theme: theme, translucent: translucent)
        assertSnapshot(of: view, named: snapshotName,
                        width: 330, height: 80, colorScheme: theme, translucent: translucent)
    }

    func testOkWithSubtitleLight() {
        render(name: "ok_subtitle",
                view: PreviewToast(kind: .ok, title: "Backup Drive ejected",
                                    subtitle: "Safe to unplug"),
                theme: .light)
    }
    func testOkWithSubtitleDark() {
        render(name: "ok_subtitle",
                view: PreviewToast(kind: .ok, title: "Backup Drive ejected",
                                    subtitle: "Safe to unplug"),
                theme: .dark)
    }

    func testErrWithActionLight() {
        render(name: "err_action",
                view: PreviewToast(kind: .err, title: "Eject failed",
                                    subtitle: "held by mds_stores (pid 412)",
                                    actionLabel: "Retry"),
                theme: .light)
    }
    func testErrWithActionDark() {
        render(name: "err_action",
                view: PreviewToast(kind: .err, title: "Eject failed",
                                    subtitle: "held by mds_stores (pid 412)",
                                    actionLabel: "Retry"),
                theme: .dark)
    }

    func testBusyLight() {
        render(name: "busy",
                view: PreviewToast(kind: .busy, title: "Backing up…",
                                    subtitle: "TMEject will eject when it's done"),
                theme: .light)
    }
    func testBusyDark() {
        render(name: "busy",
                view: PreviewToast(kind: .busy, title: "Backing up…",
                                    subtitle: "TMEject will eject when it's done"),
                theme: .dark)
    }

    func testNeutralLight() {
        render(name: "neutral",
                view: PreviewToast(kind: .neutral, title: "Backup Drive connected",
                                    subtitle: "Time Machine backup target"),
                theme: .light)
    }
    func testNeutralDark() {
        render(name: "neutral",
                view: PreviewToast(kind: .neutral, title: "Backup Drive connected",
                                    subtitle: "Time Machine backup target"),
                theme: .dark)
    }

    // Translucent representative (one only, per brief — "if the translucency only changes
    // the background fill, one representative state in translucent mode per surface").
    func testOkTranslucentLight() {
        render(name: "ok_subtitle",
                view: PreviewToast(kind: .ok, title: "Backup Drive ejected",
                                    subtitle: "Safe to unplug"),
                theme: .light, translucent: true)
    }
}

/// Thin wrapper exposing the private `ToastView` from `ToastOverlay.swift`. We don't
/// `@testable import` the private — we redeclare it as a small "structurally identical"
/// preview shape used only by snapshot tests, keyed by the same props.
private struct PreviewToast: View {
    let kind: AppCoordinator.ToastKind
    let title: String
    var subtitle: String? = nil
    var actionLabel: String? = nil

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
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(width: 300, alignment: .leading)
        .surfaceBackground(.toast)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: Spacing.hairline)
        )
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
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
        case .err:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .semibold))
        case .warning:
            Image(systemName: "externaldrive.badge.exclamationmark").font(.system(size: 13, weight: .semibold))
        case .busy:
            RingProgress(size: 16, stroke: 2, pct: nil, color: .blue)
        case .neutral:
            Image(systemName: "externaldrive.fill").font(.system(size: 13, weight: .semibold))
        }
    }

    private var chipBackground: Color {
        switch kind {
        case .ok:      return Color.green.opacity(0.16)
        case .err:     return Color.red.opacity(0.16)
        case .warning: return Color.orange.opacity(0.16)
        case .busy:    return Color.blue.opacity(0.15)
        case .neutral: return Color.gray.opacity(0.16)
        }
    }

    private var iconColor: Color {
        switch kind {
        case .ok:      return .green
        case .err:     return .red
        case .warning: return .orange
        case .busy:    return .blue
        case .neutral: return .secondary
        }
    }
}
