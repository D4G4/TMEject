import SwiftUI

struct AdvancedTab: View {
    @ObservedObject var coordinator: AppCoordinator

    @AppStorage(SettingsKey.toastsEnabled)         private var toastsEnabled = true
    @AppStorage(SettingsKey.runLsofOnEjectFailure) private var runLsofOnFailure = true
    @AppStorage(SettingsKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(SettingsKey.hasSeenLaunchHUD)      private var hasSeenLaunchHUD = false
    @State private var debugOpen = false
    @State private var dryRunResult: String?

    var body: some View {
        Form {
            Section("Eject retries") {
                Text("Schedule on busy: 2s, 5s, 15s, 30s, 60s, 120s, 300s — ~9 min total, then give up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Run lsof diagnostic on eject failure", isOn: $runLsofOnFailure)
                    .onChange(of: runLsofOnFailure) { _, on in
                        UIActionLogger.settingChanged("runLsofOnEjectFailure", value: "\(on)")
                    }
                Text("When the drive can't be ejected, list the processes holding it open and surface the result in the menu bar's \"Last error\" line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Debug", isExpanded: $debugOpen) {
                    Toggle("Show in-app toast notifications", isOn: $toastsEnabled)
                        .onChange(of: toastsEnabled) { _, on in
                            UIActionLogger.settingChanged("toastsEnabled", value: "\(on)")
                        }

                    HStack {
                        Button("Open Log Files") {
                            UIActionLogger.buttonTapped("Open Log Files", context: "Advanced")
                            LogExporter.revealInFinder()
                        }
                        Button("Reset Onboarding") {
                            UIActionLogger.buttonTapped("Reset Onboarding", context: "Advanced")
                            hasCompletedOnboarding = false
                            hasSeenLaunchHUD = false
                        }
                        Button("Test eject (dry run)") {
                            UIActionLogger.buttonTapped("Test eject dry run", context: "Advanced")
                            Task { dryRunResult = await coordinator.dryRunEject() }
                        }
                    }
                    if let dr = dryRunResult {
                        Text(dr)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
