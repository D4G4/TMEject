import SwiftUI

/// Placeholder UI per Step 12.6 — Design pass will replace it.
struct FDAOnboardingPage: View {
    @ObservedObject var coordinator: AppCoordinator
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Grant Full Disk Access")
                        .font(.title2).bold()
                    Text("Optional, but required for auto-eject to work.")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("TMEject needs to know when a backup finishes successfully — Full Disk Access lets it ask Time Machine for that.")
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Open System Settings") {
                    UIActionLogger.buttonTapped("Open Full Disk Access", context: "Onboarding")
                    NSWorkspace.shared.open(SystemSettingsLink.fullDiskAccess)
                }
                .keyboardShortcut(.defaultAction)
                Button("Check again") {
                    UIActionLogger.buttonTapped("FDA Check again", context: "Onboarding")
                    coordinator.refreshFDAState(force: true)
                }
                statusBadge
            }

            Spacer()

            HStack {
                Spacer()
                Button("Skip for now (auto-eject stays disabled)") {
                    UIActionLogger.buttonTapped("Skip FDA", context: "Onboarding")
                    onSkip()
                }
                .buttonStyle(.link)
            }
        }
        .padding(28)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch coordinator.fdaState {
        case .granted:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            Label("Not granted yet", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .unknown:
            Label("Checking…", systemImage: "questionmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
}
