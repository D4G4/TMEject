import SwiftUI
import KeyboardShortcuts
import AppKit

struct GeneralTab: View {
    @ObservedObject var coordinator: AppCoordinator

    @AppStorage(SettingsKey.autoEjectEnabled) private var autoEjectEnabled = false
    @AppStorage(SettingsKey.cooldownMinutes)  private var cooldownMinutes = 30
    @AppStorage(SettingsKey.notifyOnBackupFailure) private var notifyOnBackupFailure = true

    @State private var loginItemError: String?
    @State private var fdaCheckInFlight = false

    var body: some View {
        Form {
            Section("Permissions") {
                HStack {
                    Text("Full Disk Access")
                    Spacer()
                    fdaStatusBadge
                    Button(fdaCheckInFlight ? "Checking…" : "Check again") {
                        fdaCheckInFlight = true
                        coordinator.refreshFDAState(force: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { fdaCheckInFlight = false }
                    }
                    .controlSize(.small)
                    .disabled(fdaCheckInFlight)
                    Button("Open Settings") {
                        UIActionLogger.buttonTapped("Open Full Disk Access", context: "General")
                        NSWorkspace.shared.open(SystemSettingsLink.fullDiskAccess)
                    }
                    .controlSize(.small)
                }
                Text("Required so TMEject can ask Time Machine whether the latest backup actually completed. `tmutil status -X` doesn't need this; `tmutil latestbackup` does.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Auto-eject") {
                Toggle("Eject the drive after a successful backup",
                       isOn: Binding(
                        get: { autoEjectEnabled },
                        set: { newValue in coordinator.setAutoEjectEnabled(newValue) }
                       ))

                if autoEjectEnabled && coordinator.fdaState != .granted {
                    Text("Required to detect backup completion. Open Settings to grant Full Disk Access.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Picker("Cooldown between auto-ejects", selection: $cooldownMinutes) {
                    ForEach(CooldownOption.allCases) { opt in
                        Text(opt.label).tag(opt.rawValue)
                    }
                }
                .onChange(of: cooldownMinutes) { _, v in
                    UIActionLogger.settingChanged("cooldownMinutes", value: "\(v)")
                }
                .disabled(!autoEjectEnabled)

                Text("Hourly Time Machine backups plus auto-eject can trap you in a loop where the drive ejects, the next backup can't reach it, and you have to physically reconnect. A 30-minute cooldown gives you breathing room.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Notify me when a backup fails", isOn: $notifyOnBackupFailure)
                    .onChange(of: notifyOnBackupFailure) { _, on in
                        UIActionLogger.settingChanged("notifyOnBackupFailure", value: "\(on)")
                    }
            }

            Section("Launch") {
                Toggle("Launch TMEject at login", isOn: Binding(
                    get: { coordinator.loginItemStatus == .enabled },
                    set: { newValue in
                        do {
                            try coordinator.setLaunchAtLogin(newValue)
                            loginItemError = nil
                        } catch {
                            loginItemError = "\(error)"
                        }
                    }
                ))
                if coordinator.loginItemStatus == .requiresApproval {
                    HStack(alignment: .firstTextBaseline) {
                        Text("macOS needs your approval to launch TMEject at login.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items in System Settings") {
                            UIActionLogger.buttonTapped("Open Login Items", context: "General")
                            NSWorkspace.shared.open(LoginItemSettings.url)
                        }
                        .controlSize(.small)
                    }
                }
                if let err = loginItemError {
                    Text("Login item error: \(err)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Keyboard Shortcut") {
                HStack {
                    Text("Eject & Lock")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .ejectAndLock)
                        .frame(width: 160)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            coordinator.refreshLoginItemStatus()
            coordinator.refreshFDAState()
        }
    }

    @ViewBuilder
    private var fdaStatusBadge: some View {
        switch coordinator.fdaState {
        case .granted:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
                .font(.caption)
        case .denied:
            Label("Not granted", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .labelStyle(.titleAndIcon)
                .font(.caption)
        case .unknown:
            Label("Unknown", systemImage: "questionmark.circle.fill")
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .font(.caption)
        }
    }
}
