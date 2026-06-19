import SwiftUI

/// State-driven menu bar status icon, ported from `icons.jsx::MenuBarIcon`. Color is
/// carried by the state language (ring presence/shape/motion) — color-blind safe.
struct MenuBarIconView: View {
    let state: AppState
    let ejectPct: Double

    var body: some View {
        ZStack {
            switch state {
            case .idle:
                Image(systemName: "eject.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityLabel("TMEject — idle")
            case .backingUp:
                ZStack {
                    RingProgress(size: 18, stroke: 1.6, pct: nil, color: .primary)
                    Image(systemName: "eject.fill")
                        .font(.system(size: 8, weight: .semibold))
                }
                .accessibilityLabel("TMEject — backing up")
            case .confirming:
                ZStack {
                    RingProgress(size: 18, stroke: 1.6, pct: 100, color: .primary)
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .accessibilityLabel("TMEject — verifying backup")
            case .ejecting:
                ZStack {
                    RingProgress(size: 18, stroke: 1.8, pct: max(6, ejectPct), color: .primary)
                    Image(systemName: "eject.fill")
                        .font(.system(size: 7.5, weight: .semibold))
                }
                .accessibilityLabel("TMEject — ejecting, \(Int(ejectPct.rounded())) percent")
            case .idleEjectFailed:
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .opacity(0.5)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                        .offset(x: 2, y: 1)
                }
                .accessibilityLabel("TMEject — eject failed")
            }
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - Previews

#if DEBUG
private struct MenuBarIconPreviewRow: View {
    let label: String
    let state: AppState
    var ejectPct: Double = 0

    var body: some View {
        HStack(spacing: 14) {
            MenuBarIconView(state: state, ejectPct: ejectPct)
                .frame(width: 22, height: 22)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("All states · Light") {
    VStack(alignment: .leading, spacing: 12) {
        MenuBarIconPreviewRow(label: "idle", state: .idle)
        MenuBarIconPreviewRow(label: "backingUp", state: .backingUp)
        MenuBarIconPreviewRow(label: "confirming", state: .confirming)
        MenuBarIconPreviewRow(label: "ejecting · 50%", state: .ejecting, ejectPct: 50)
        MenuBarIconPreviewRow(label: "idleEjectFailed", state: .idleEjectFailed)
    }
    .padding(20)
    .frame(width: 220, alignment: .leading)
    .background(Color.surfacePopover)
    .environment(\.colorScheme, .light)
}

#Preview("All states · Dark") {
    VStack(alignment: .leading, spacing: 12) {
        MenuBarIconPreviewRow(label: "idle", state: .idle)
        MenuBarIconPreviewRow(label: "backingUp", state: .backingUp)
        MenuBarIconPreviewRow(label: "confirming", state: .confirming)
        MenuBarIconPreviewRow(label: "ejecting · 50%", state: .ejecting, ejectPct: 50)
        MenuBarIconPreviewRow(label: "idleEjectFailed", state: .idleEjectFailed)
    }
    .padding(20)
    .frame(width: 220, alignment: .leading)
    .background(Color.surfacePopover)
    .environment(\.colorScheme, .dark)
}
#endif
