import SwiftUI
import KeyboardShortcuts
import AppKit

struct GeneralTab: View {
    @ObservedObject var coordinator: AppCoordinator

    @AppStorage(SettingsKey.autoEjectEnabled) private var autoEjectEnabled = false
    @AppStorage(SettingsKey.cooldownMinutes)  private var cooldownMinutes = 30
    @AppStorage(SettingsKey.notifyOnBackupFailure) private var notifyOnBackupFailure = true

    @State private var loginItemStatus: LoginItemStatus = .notRegistered
    @State private var loginItemError: String?
    private let loginItem: LoginItemManaging = LiveLoginItemManager()

    var body: some View {
        Form {
            Section("Auto-eject") {
                Toggle("Eject the drive after a successful backup", isOn: $autoEjectEnabled)
                    .onChange(of: autoEjectEnabled) { _, on in
                        UIActionLogger.settingChanged("autoEjectEnabled", value: "\(on)")
                        if on {
                            Task { _ = await coordinator.requestNotificationAuthIfNeeded() }
                        }
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
                    get: { loginItemStatus == .enabled },
                    set: { newValue in
                        UIActionLogger.settingChanged("launchAtLogin", value: "\(newValue)")
                        do {
                            if newValue {
                                try loginItem.register()
                            } else {
                                try loginItem.unregister()
                            }
                            loginItemError = nil
                        } catch {
                            loginItemError = "\(error)"
                        }
                        loginItemStatus = loginItem.currentStatus()
                    }
                ))
                if loginItemStatus == .requiresApproval {
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
            loginItemStatus = loginItem.currentStatus()
        }
    }
}
