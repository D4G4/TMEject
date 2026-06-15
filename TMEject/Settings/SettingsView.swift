import SwiftUI
import KeyboardShortcuts
import AppKit

/// Single-pane scrolling Settings, ported from the Design pass. No tabs.
struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator

    @AppStorage(SettingsKey.autoEjectEnabled)    private var autoEjectEnabled = true
    @AppStorage(SettingsKey.cooldownMinutes)     private var cooldownMinutes  = 30
    @AppStorage(SettingsKey.betaChannel)         private var betaChannel      = false
    @AppStorage(SettingsKey.toastsEnabled)       private var toastsEnabled    = true
    @AppStorage(SettingsKey.translucentSurfaces) private var translucentSurfaces = false
    @AppStorage(SettingsKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(SettingsKey.forceOnboardingModal) private var forceOnboardingModal = false

    @State private var troubleshootingOpen = false
    @State private var loginItemError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                fdaPillBanner
                section("BEHAVIOR") {
                    Group {
                        row(title: "Auto-eject after backup",
                            subtitle: "Eject the drive automatically once a Time Machine backup finishes.") {
                            Toggle("", isOn: Binding(
                                get: { autoEjectEnabled },
                                set: { coordinator.setAutoEjectEnabled($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                        Divider().opacity(0.6)
                        row(title: "Skip if next backup is near",
                            subtitle: "Don’t eject if another backup is due within the cooldown window.") {
                            Stepper(value: $cooldownMinutes, in: 0...360, step: 15) {
                                Text("\(cooldownMinutes) min")
                                    .font(.system(size: 13))
                                    .monospacedDigit()
                            }
                            .controlSize(.small)
                            .fixedSize()
                        }
                        .opacity(autoEjectEnabled ? 1 : 0.45)
                    }
                }

                section("EJECT & LOCK") {
                    row(title: "Keyboard shortcut",
                        subtitle: "Eject the drive and lock the screen in one motion.") {
                        KeyboardShortcuts.Recorder(for: .ejectAndLock)
                            .frame(width: 130)
                    }
                }

                section("GENERAL") {
                    row(title: "Launch at login", subtitle: nil) {
                        Toggle("", isOn: Binding(
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
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    if coordinator.loginItemStatus == .requiresApproval {
                        Divider().opacity(0.6)
                        row(title: "Approve in System Settings",
                            subtitle: "macOS needs your approval to launch TMEject at login.") {
                            Button("Open") {
                                UIActionLogger.buttonTapped("Open Login Items", context: "Settings")
                                NSWorkspace.shared.open(LoginItemSettings.url)
                            }
                            .controlSize(.small)
                        }
                    }
                    if let err = loginItemError {
                        Divider().opacity(0.6)
                        row(title: "Login item error", subtitle: err) { EmptyView() }
                    }
                    Divider().opacity(0.6)
                    row(title: "Receive beta updates",
                        subtitle: "Get new versions earlier. May be less stable.") {
                        Toggle("", isOn: $betaChannel)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    Divider().opacity(0.6)
                    row(title: "Translucent windows",
                        subtitle: "Use macOS material backgrounds. May reduce readability over busy wallpapers.") {
                        Toggle("", isOn: $translucentSurfaces)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }

                // Troubleshooting disclosure
                troubleshootingDisclosure
                    .padding(.horizontal, 20)
                    .padding(.top, 10)

                if troubleshootingOpen {
                    section("") {
                        row(title: "Open log files",
                            subtitle: "For diagnosing eject failures.") {
                            Button("Reveal in Finder") {
                                LogExporter.revealInFinder()
                                UIActionLogger.buttonTapped("Reveal logs", context: "Settings/Troubleshooting")
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.blue)
                        }
                        Divider().opacity(0.6)
                        row(title: "Show in-app toast notifications",
                            subtitle: "Quick on-screen confirmations.") {
                            Toggle("", isOn: $toastsEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                        Divider().opacity(0.6)
                        row(title: "Reset onboarding",
                            subtitle: "Show the explainer next time TMEject launches.") {
                            Button("Reset") {
                                hasCompletedOnboarding = false
                                forceOnboardingModal = true
                                UIActionLogger.buttonTapped("Reset onboarding", context: "Settings/Troubleshooting")
                            }
                            .controlSize(.small)
                        }
                    }
                    .transition(.opacity)
                }

                Text(footerText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .frame(width: Spacing.windowWidth)
        .frame(minHeight: 360, maxHeight: Spacing.windowMaxHeight)
        .surfaceBackground(.window)
        .onAppear {
            coordinator.refreshLoginItemStatus()
            coordinator.refreshFDAState()
            coordinator.refreshDrivePresence()
        }
    }

    // MARK: - Components

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        if !title.isEmpty {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        VStack(spacing: 0) { content() }
            .surfaceBackground(.card)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: Spacing.hairline)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func row<Trailing: View>(title: String, subtitle: String?,
                                      @ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: Spacing.settingsRowHeight)
    }

    private var troubleshootingDisclosure: some View {
        Button {
            withAnimation { troubleshootingOpen.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: troubleshootingOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Text("Troubleshooting")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footerText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "TMEject \(v) · macOS 14+ · Quit from the menu bar"
    }

    @ViewBuilder
    private var fdaPillBanner: some View {
        let needsFDA = autoEjectEnabled && coordinator.fdaState != .granted
        if needsFDA {
            Button {
                UIActionLogger.buttonTapped("Open Full Disk Access", context: "Settings-pill")
                NSWorkspace.shared.open(SystemSettingsLink.fullDiskAccess)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 12))
                    Text("Auto-eject paused · Grant Full Disk Access")
                        .font(.system(size: 12))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(Color.orange.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.orange.opacity(0.55), lineWidth: Spacing.hairline)
                )
                .foregroundStyle(Color.orange)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
    }
}
